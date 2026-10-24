export function Total({ lines }: { lines: LineItem[] }) {
  const { t } = useTranslation();
  const sum = lines.reduce((acc, line) => acc + line.quantity * line.unitPrice, 0);
  return <p>{t("cart.total", { amount: formatMoney(sum) })}</p>;
}
